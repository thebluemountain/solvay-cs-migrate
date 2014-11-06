using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace dmqdocbroker
{
    class Program
    {
        static void Main(string[] args)
        {
            if (args.Contains("ping", new CiEqualityComparer()))
            {
                Console.WriteLine("Successful reply from docbroker at host");
                return;
            }

            if (args.Contains("getservermap", new CiEqualityComparer()))
            {
                Console.WriteLine("[DM_DOCBROKER_E_NO_SERVERS_FOR_DOCBASE]error:");
                return;
            }

             Console.WriteLine("This is a dummy implementation of dmqdocbroker that returns" +
                   "the string \"Successful reply from docbroker at host\" when passed \"ping\" as an argument, " +
                   "and \"[DM_DOCBROKER_E_NO_SERVERS_FOR_DOCBASE]xxx\" when passed \"getservermap\"");
        }
    }
}
